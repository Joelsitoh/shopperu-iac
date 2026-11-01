export const handler = async () => {
  const productos = [
    { id: 1, nombre: "Polo de algodon", precio: 39.9, stock: 25 },
    { id: 2, nombre: "Zapatillas urbanas", precio: 189.0, stock: 8 }
  ];

  return {
    statusCode: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(productos)
  };
};
